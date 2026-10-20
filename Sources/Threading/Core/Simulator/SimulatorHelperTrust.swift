import Foundation
import Security

enum SimulatorHelperLocation {
    static let executableName = "threading-simulator-helper"
    static let identifier = "codes.threading.simulator-helper"
    static let pluginName = NativePluginManagedOffer.devices.bundleName
    static let pluginIdentifier = NativePluginManagedOffer.devices.identifier

    static func bundledExecutable(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
    }

    static func installedPlugin(in directory: URL = NativePluginManagedPaths.directory) -> URL {
        directory.appendingPathComponent(pluginName, isDirectory: true)
    }

    static func installedExecutable(in directory: URL = NativePluginManagedPaths.directory) -> URL {
        installedPlugin(in: directory)
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
    }

    static func candidates(
        in bundle: Bundle = .main,
        directory: URL = NativePluginManagedPaths.directory
    ) -> [URL] {
        [installedExecutable(in: directory), bundledExecutable(in: bundle)]
    }
}

enum SimulatorHelperTrust {
    static func availableExecutable(
        in bundle: Bundle = .main,
        directory: URL = NativePluginManagedPaths.directory
    ) throws -> URL {
        var refusal: Error?
        for candidate in SimulatorHelperLocation.candidates(in: bundle, directory: directory) {
            // A managed install is published through a replaceable symlink. Pin the version
            // path before checking it so a concurrent refresh cannot change what Process runs.
            let executable = candidate.resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
            do {
                try verify(executableURL: executable, bundle: bundle, directory: directory)
                return executable
            } catch {
                refusal = error
            }
        }
        if let refusal { throw refusal }
        throw SimulatorLiveStreamError.helperUnavailable(
            L10n.string("Install Devices in Extensions Settings for live Simulator control.")
        )
    }

    static func verify(
        executableURL: URL,
        bundle: Bundle = .main,
        directory: URL = NativePluginManagedPaths.directory
    ) throws {
        guard executableURL.isFileURL else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "The direct Simulator helper is not a local file."
            )
        }
        let path = executableURL.standardizedFileURL
        let bundled = SimulatorHelperLocation.bundledExecutable(in: bundle)
            .resolvingSymlinksInPath().standardizedFileURL
        let installed = SimulatorHelperLocation.installedExecutable(in: directory)
            .resolvingSymlinksInPath().standardizedFileURL
        guard path == bundled || path == installed else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "The direct Simulator helper is outside the Devices plugin."
            )
        }
        if path == installed {
            try verifyManagedPlugin(directory: directory, app: bundle.bundleURL, helper: path)
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode,
        SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            nil
        ) == errSecSuccess else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "The direct Simulator helper has an invalid code signature."
            )
        }

        let helper = try signingInformation(staticCode)
        guard helper[kSecCodeInfoIdentifier as String] as? String
            == SimulatorHelperLocation.identifier else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "The embedded Simulator helper has an unexpected signing identifier."
            )
        }
        guard let hostExecutableURL = bundle.executableURL else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "Threading could not read its own code signature."
            )
        }
        var hostCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            hostExecutableURL as CFURL,
            SecCSFlags(),
            &hostCode
        ) == errSecSuccess, let hostCode else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "Threading could not read its own code signature."
            )
        }
        let host = try signingInformation(hostCode)
        let helperTeam = helper[kSecCodeInfoTeamIdentifier as String] as? String
        let hostTeam = host[kSecCodeInfoTeamIdentifier as String] as? String
        if helperTeam != nil || hostTeam != nil {
            guard helperTeam == hostTeam else {
                throw SimulatorLiveStreamError.signatureInvalid(
                    "Threading and its Simulator helper are signed by different teams."
                )
            }
        }
    }

    private static func signingInformation(_ code: SecStaticCode) throws -> [String: Any] {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let information = information as? [String: Any] else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "Threading could not inspect the Simulator helper signature."
            )
        }
        return information
    }

    private static func verifyManagedPlugin(directory: URL, app: URL, helper: URL) throws {
        let plugin = SimulatorHelperLocation.installedPlugin(in: directory)
        let resolved = plugin.resolvingSymlinksInPath()
        let expectedHelper = resolved
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(SimulatorHelperLocation.executableName)
        guard helper.standardizedFileURL == expectedHelper.standardizedFileURL else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "The direct Simulator helper leaves its managed plugin bundle."
            )
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(resolved as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "Threading could not inspect the installed Devices plugin."
            )
        }
        let information = try signingInformation(staticCode)
        let identifier = information[kSecCodeInfoIdentifier as String] as? String
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String
        let codeHash = (information[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }.joined()
        guard identifier == SimulatorHelperLocation.pluginIdentifier,
              let codeHash,
              NativePluginManagedReceipt.approves(
                bundle: plugin,
                identifier: SimulatorHelperLocation.pluginIdentifier,
                team: team,
                codeDirectoryHash: codeHash,
                app: app,
                directory: directory,
                expectedResolvedBundle: resolved
              ) else {
            throw SimulatorLiveStreamError.signatureInvalid(
                "The installed Devices plugin does not match this signed Threading release."
            )
        }
    }
}

enum SimulatorDeveloperDirectory {
    static func active() throws -> String {
        if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           !configured.isEmpty {
            return configured
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() }
        catch {
            throw SimulatorLiveStreamError.helperUnavailable(
                "Threading could not find the active Xcode developer directory."
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              data.count <= 4_096,
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw SimulatorLiveStreamError.helperUnavailable(
                "Threading could not find the active Xcode developer directory."
            )
        }
        return path
    }
}
